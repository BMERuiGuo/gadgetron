#include "htgrappa.h"
//#include <cublas.h>

#include <cublas_v2.h>
#include <cula_lapack_device.h>
#include "hoNDArray_fileio.h"
#include "cuNDFFT.h"
#include "GPUTimer.h"

#include "CUBLASContextProvider.h"

#include <iostream>

using namespace Gadgetron;
int2 vec_to_int2(std::vector<unsigned int> vec)
{
	int2 ret; ret.x = 0; ret.y = 0;
	if (vec.size() < 2) {
		std::cout << "vec_to_uint2 dimensions of vector too small" << std::endl;
		return ret;
	}

	ret.x = vec[0]; ret.y = vec[1];
	return ret;
}


__global__ void clear_array(complext<float> * in, unsigned long int elements)
{
	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;
	if (idx_in < elements) {
		in[idx_in] = complext<float>(0);
	}
}

int clear(cuNDArray<complext<float> >* in)
{
	dim3 blockDim(512,1,1);
	dim3 gridDim((unsigned int) ceil((double)in->get_number_of_elements()/blockDim.x), 1, 1 );

	clear_array<<< gridDim, blockDim >>>( in->get_data_ptr(), in->get_number_of_elements());

	cudaError_t err = cudaGetLastError();
	if( err != cudaSuccess ){
		std::cerr << "clear : Error during kernel call: " << cudaGetErrorString(err) << std::endl;
		return -1;
	}

	return 0;
}

template <class T> int write_cuNDArray_to_disk(cuNDArray<T>* a, const char* filename)
{
	hoNDArray<T> host = a->to_host();
	write_nd_array<complext<float> >(host, filename);
	return 0;
}

template <class T> __global__ void form_grappa_system_matrix_kernel_2d(T* ref_data,
		int2 dims,
		int source_coils,
		int target_coils,
		int2 ros,
		int2 ros_offset,
		int2 kernel_size,
		int acceleration_factor,
		int set_number,
		T* out_matrix,
		T* b)
{
	long idx_in = blockIdx.x*blockDim.x+threadIdx.x;
	int klocations = ros.x*ros.y;
	int image_elements = dims.x*dims.y;
	//int coefficients = kernel_size.x*kernel_size.y*coils;
	if (idx_in < klocations) {
		//unsigned int y = idx_in/ros.x;
		//unsigned int x = idx_in - y*ros.x;
		unsigned int x = idx_in/ros.y;
		unsigned int y = idx_in - x*ros.y;
		unsigned int idx_ref = 0;
		unsigned int coeff_counter = 0;

		int kernel_size_x = kernel_size.x;
		int kernel_size_y = kernel_size.y;

		for (int c = 0; c < source_coils; c++) {
			for (int ky = -((kernel_size_y*acceleration_factor)>>1)+set_number+1;
					ky < ((kernel_size_y*acceleration_factor+1)>>1); ky+=acceleration_factor) {
				for (int kx = -(kernel_size_x>>1); kx < ((kernel_size_x+1)>>1); kx++) {
					idx_ref = c*image_elements + x+kx+ros_offset.x + (y+ky+ros_offset.y)*dims.x;
					//out_matrix[idx_in*coefficients+coeff_counter++] = ref_data[idx_ref];
					out_matrix[idx_in+(coeff_counter++)*klocations] = ref_data[idx_ref];

				}
			}
		}

		//Loop over target coils here
		for (unsigned int c = 0; c < target_coils; c++) {
			//b[idx_in*coils + c] = ref_data[c*image_elements + y*dims.x+x];
			b[idx_in + c*klocations] = ref_data[c*image_elements + (y+ros_offset.y)*dims.x+(x+ros_offset.x)];
		}
	}
}

//TODO: This should take source and target coils into consideration
template <class T> __global__ void copy_grappa_coefficients_to_kernel_2d(T* coeffs,
		T* kernel,
		int source_coils,
		int target_coils,
		int2 kernel_size,
		int acceleration_factor,
		int set)
{
	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	unsigned int coefficients_in_set = source_coils*kernel_size.x*kernel_size.y*target_coils;

	if (idx_in < coefficients_in_set) {
		int idx_in_tmp = idx_in;
		int kx = idx_in%kernel_size.x;
		idx_in = (idx_in-kx)/kernel_size.x;
		int ky = idx_in%kernel_size.y;
		idx_in = (idx_in-ky)/kernel_size.y;
		int coil = idx_in%source_coils;
		idx_in = (idx_in-coil)/source_coils;
		int coilg = idx_in;

		kernel[coilg*source_coils*(kernel_size.y*acceleration_factor)*kernel_size.x +
		       coil*(kernel_size.y*acceleration_factor)*kernel_size.x +
		       (ky*acceleration_factor + set + 1)*kernel_size.x + kx] = coeffs[idx_in_tmp];

		if ((coil == coilg) && (kx == 0) && (ky == 0) && (set == 0)) {
			kernel[coilg*source_coils*(kernel_size.y*acceleration_factor)*kernel_size.x +
			       coil*(kernel_size.y*acceleration_factor)*kernel_size.x +
			       ((kernel_size.y>>1)*acceleration_factor)*kernel_size.x + (kernel_size.x>>1) ].vec[0] = 1;

		}
	}
}

template <class T> __global__ void copy_grappa_kernel_to_kspace_2d(T* kernel,
		T* out,
		int2 dims,
		int2 kernel_size,
		int coils)

{

	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	if (idx_in < kernel_size.x*kernel_size.y*coils) {
		int idx_in_tmp = idx_in;
		int kx = idx_in%kernel_size.x;
		idx_in = (idx_in-kx)/kernel_size.x;
		int ky = idx_in%kernel_size.y;
		idx_in = (idx_in-ky)/kernel_size.y;
		int coil = idx_in;

		int outx = -(kx- (kernel_size.x>>1)) + (dims.x>>1); //Flipping the kernel for conv
		int outy = -(ky- (kernel_size.y>>1)) + (dims.y>>1);

		out[coil*dims.x*dims.y + outy*dims.x + outx] = kernel[idx_in_tmp];
	}

}

__global__ void scale_and_add_unmixing_coeffs(complext<float> * unmixing,
		complext<float> * csm,
		complext<float> * out,
		int elements,
		int coils,
		float scale_factor)
{
	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	complext<float>  tmp;
	if (idx_in < elements) {
		for (int c = 0; c < coils; c++) {
			tmp = unmixing[c*elements + idx_in]*conj(csm[idx_in]);
			out[c*elements + idx_in] += scale_factor*tmp;

		}
	}
}

__global__ void scale_and_copy_unmixing_coeffs(complext<float> * unmixing,
		complext<float> * out,
		int elements,
		int coils,
		float scale_factor)
{
	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	if (idx_in < elements) {
		for (int c = 0; c < coils; c++) {
			out[c*elements + idx_in] = scale_factor*unmixing[c*elements + idx_in];

		}
	}
}

__global__ void conj_csm_coeffs(complext<float> * csm,
		complext<float> * out,
		int source_elements,
		int target_elements)
{
	//TODO: Here we need to have both src_elements and target_elements and we use conj(csm) for all target_elements and 0.0 when element > target_elements

	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	if (idx_in < source_elements) {
		if (idx_in >= target_elements) {
			out[idx_in] = complext<float> (0.0,0.0);
		} else {
			out[idx_in] = conj(csm[idx_in]);
		}
	}
}

__global__ void single_channel_coeffs(complext<float> * out,
		int channel_no,
		int elements_per_channel)
{
	unsigned long idx_in = blockIdx.x*blockDim.x+threadIdx.x;

	if (idx_in < elements_per_channel) {
		out[idx_in + channel_no*elements_per_channel] = complext<float>(1.0,0.0);
	}
}


template <class T> int htgrappa_calculate_grappa_unmixing(cuNDArray<T>* ref_data, 
		cuNDArray<T>* b1,
		unsigned int acceleration_factor,
		std::vector<unsigned int>* kernel_size,
		cuNDArray<T>* out_mixing_coeff,
		std::vector< std::pair<unsigned int, unsigned int> >* sampled_region,
		std::list< unsigned int >* uncombined_channels)
{

	if (ref_data->get_number_of_dimensions() != b1->get_number_of_dimensions()) {
		std::cerr << "htgrappa_calculate_grappa_unmixing: Dimensions mismatch" << std::endl;
		return -1;
	}

	for (unsigned int i = 0; i < (ref_data->get_number_of_dimensions()-1); i++) {
		if (ref_data->get_size(i) != b1->get_size(i)) {
			std::cerr << "htgrappa_calculate_grappa_unmixing: Dimensions mismatch" << std::endl;
			return -1;
		}
	}


	unsigned int source_coils = ref_data->get_size(ref_data->get_number_of_dimensions()-1);
	unsigned int target_coils = b1->get_size(b1->get_number_of_dimensions()-1);
	unsigned int elements_per_coil = b1->get_number_of_elements()/target_coils;

	if (target_coils > source_coils) {
		std::cerr << "target_coils > source_coils" << std::endl;
		return -1;
	}

	if (acceleration_factor == 1) {
		dim3 blockDim(512,1,1);
		dim3 gridDim((unsigned int) ceil((1.0f*elements_per_coil*source_coils)/blockDim.x), 1, 1 );

		conj_csm_coeffs<<< gridDim, blockDim >>>( b1->get_data_ptr(),
				out_mixing_coeff->get_data_ptr(),
				out_mixing_coeff->get_number_of_elements(),
				b1->get_number_of_elements());

		std::list<unsigned int>::iterator it;
		gridDim = dim3((unsigned int) ceil((1.0f*(elements_per_coil))/blockDim.x), 1, 1 );
		int uncombined_channel_no = 0;
		for ( it = uncombined_channels->begin(); it != uncombined_channels->end(); it++ ) {
			uncombined_channel_no++;
			//TODO: Adjust pointers to reflect that number of target/source may not be qual
			single_channel_coeffs<<< gridDim, blockDim >>>( out_mixing_coeff->get_data_ptr() + uncombined_channel_no*source_coils*elements_per_coil,
					*it,
					(elements_per_coil));
		}
		return 0;
	}

	if (kernel_size->size() != (ref_data->get_number_of_dimensions()-1)) {
		std::cerr << "htgrappa_calculate_grappa_unmixing: Kernel size does not match the data dimensions" << std::endl;
		return -1;
	}

	if (ref_data->get_number_of_dimensions() > 3) {
		std::cerr << "htgrappa_calculate_grappa_unmixing: Not yet implemented for 3D" << std::endl;
		return -1;
	}

	//Calculate region of support + offsets
	std::vector<unsigned int> ros = *ref_data->get_dimensions();
	ros.pop_back(); //Remove the number of coils
	std::vector<unsigned int> ros_offset(ref_data->get_number_of_dimensions(),0);
	unsigned long int kspace_locations = 1;

	if (sampled_region) {
		for (unsigned int i = 0; i < ros.size(); i++) {
			if (i > 0) {
				ros[i] = (*sampled_region)[i].second-(*sampled_region)[i].first-((*kernel_size)[i]*acceleration_factor);
			} else {
				ros[i] = (*sampled_region)[i].second-(*sampled_region)[i].first-(*kernel_size)[i];
			}
			ros_offset[i] = (*sampled_region)[i].first+(((*sampled_region)[i].second-(*sampled_region)[i].first-ros[i])>>1);
			kspace_locations *= ros[i];
		}
	} else {
		for (unsigned int i = 0; i < ros.size(); i++) {
			if (i > 0) {
				ros[i] -= ((*kernel_size)[i]*acceleration_factor);
			} else {
				ros[i] -= (*kernel_size)[i];
			}
			ros_offset[i] = (ref_data->get_size(i)-ros[i])>>1;
			kspace_locations *= ros[i];
		}
	}

	/*
  for (unsigned int i = 0; i < ros.size(); i++) {
    std::cout << "ROS[" << i << "] = " << ros[i] << " + " << ros_offset[i] << std::endl;
  }
	 */

	std::vector<unsigned int> sys_matrix_size;
	sys_matrix_size.push_back(kspace_locations);
	sys_matrix_size.push_back(source_coils*(*kernel_size)[0]*(*kernel_size)[1]);

	std::vector<unsigned int> b_size;
	b_size.push_back(kspace_locations);
	b_size.push_back(target_coils);

	cuNDArray<T> system_matrix = cuNDArray<T>(&sys_matrix_size);

	clear(&system_matrix);

	cuNDArray<T> b = cuNDArray<T>(&b_size);

	int2 dims = vec_to_int2(*ref_data->get_dimensions());
	int2 dros = vec_to_int2(ros);
	int2 dros_offset = vec_to_int2(ros_offset);
	int2 dkernel_size = vec_to_int2(*kernel_size);

	//TODO: Use source coils here
	int n = source_coils*(*kernel_size)[0]*(*kernel_size)[1];
	int m = kspace_locations;

	std::vector<unsigned int> AHA_dims(2,n);
	cuNDArray<T> AHA = cuNDArray<T>(&AHA_dims);

	//TODO: Use target coils here
	std::vector<unsigned int> AHrhs_dims;
	AHrhs_dims.push_back(n);
	AHrhs_dims.push_back(target_coils);

	cuNDArray<T> AHrhs = cuNDArray<T>(&AHrhs_dims);

	cublasHandle_t handle = *CUBLASContextProvider::instance()->getCublasHandle();
	/*
	if (cublasCreate_v2(&handle) != CUBLAS_STATUS_SUCCESS) {
		std::cerr << "htgrappa_calculate_grappa_unmixing: unable to create cublas handle" << std::endl;
		return -1;

	}
	*/

	std::vector<unsigned int> gkernel_dims;
	gkernel_dims.push_back((*kernel_size)[0]);
	gkernel_dims.push_back((*kernel_size)[1]*acceleration_factor);
	gkernel_dims.push_back(source_coils);
	gkernel_dims.push_back(target_coils);
	cuNDArray<T> gkernel = cuNDArray<T>(&gkernel_dims);
	clear(&gkernel);

	for (unsigned int set = 0; set < acceleration_factor-1; set++) {
		//std::cout << "Calculating coefficients for set " << set << std::endl;

		//std::cout << "dros.x = " << dros.x << ", dros.y = " << dros.y << std::endl;

		dim3 blockDim(512,1,1);
		dim3 gridDim((unsigned int) ceil((1.0f*kspace_locations)/blockDim.x), 1, 1 );

		form_grappa_system_matrix_kernel_2d<<< gridDim, blockDim >>>( ref_data->get_data_ptr(), dims,
				source_coils, target_coils, dros, dros_offset,
				dkernel_size, acceleration_factor, set,
				system_matrix.get_data_ptr(),
				b.get_data_ptr());

		cudaError_t err = cudaGetLastError();
		if( err != cudaSuccess ){
			std::cerr << "htgrappa_calculate_grappa_unmixing: Unable to form system matrix: " <<
					cudaGetErrorString(err) << std::endl;
			return -1;
		}

		//write_cuNDArray_to_disk(&system_matrix,"A.cplx");
		//write_cuNDArray_to_disk(&b,"b.cplx");

		complext<float>  alpha = complext<float>(1);
		complext<float>  beta = complext<float>(0);

		cublasStatus_t stat = cublasCgemm(handle, CUBLAS_OP_C, CUBLAS_OP_N,
				n,n,m,(float2*) &alpha,
				(float2*) system_matrix.get_data_ptr(), m,
				(float2*) system_matrix.get_data_ptr(), m,
				(float2*) &beta, (float2*) AHA.get_data_ptr(), n);

		if (stat != CUBLAS_STATUS_SUCCESS) {
			std::cerr << "htgrappa_calculate_grappa_unmixing: Failed to form AHA product using cublas gemm" << std::endl;
			std::cerr << "---- cublas error code " << stat << std::endl;
			return -1;
		}

		//write_cuNDArray_to_disk(&AHA,"AHA.cplx");

		{

			//GPUTimer timer("GRAPPA cublas gemm");
			//TODO: Sort out arguments for source and target coils here.
			stat = cublasCgemm(handle, CUBLAS_OP_C, CUBLAS_OP_N,
					n,target_coils,m,(float2*) &alpha,
					(float2*) system_matrix.get_data_ptr(), m,
					(float2*) b.get_data_ptr(), m,
					(float2*) &beta, (float2*)AHrhs.get_data_ptr(), n);

		}
		//write_cuNDArray_to_disk(&AHrhs,"AHrhs.cplx");

		if (stat != CUBLAS_STATUS_SUCCESS) {
			std::cerr << "htgrappa_calculate_grappa_unmixing: Failed to form AHA product using cublas gemm" << std::endl;
			std::cerr << "---- cublas error code " << stat << std::endl;
			return -1;
		}


		culaStatus s;
		/*
		s = culaInitialize();
		if(s != culaNoError) {
			std::cerr << "htgrappa: failed to initialize CULA" << std::endl;
			return -1;
		}
		*/

		s = culaDeviceCgels( 'N', n, n, target_coils,
				(culaDeviceFloatComplex*)AHA.get_data_ptr(), n,
				(culaDeviceFloatComplex*)AHrhs.get_data_ptr(), n);


		if (s != culaNoError) {
			std::cout << "htgrappa_calculate_grappa_unmixing: linear solve failed" << std::endl;
			return -1;
		}

#if 0
	    size_t free = 0, total = 0;
	    cudaMemGetInfo(&free, &total);
	    std::cout << "CUDA Memory: " << free << " (" << total << ")" << std::endl;
#endif
		//culaShutdown();

		/*
			if (cposv_wrapper(&AHA, &AHrhs) < 0) {
			  std::cerr << "htgrappa_calculate_grappa_unmixing: Error calling cgels" << std::endl;
			  return -1;
			}
		 */

		//write_cuNDArray_to_disk(&AHrhs,"AHrhs_solution.cplx");

		gridDim = dim3((unsigned int) ceil((1.0f*n*source_coils)/blockDim.x), 1, 1 );

		//TODO: This should be target coils used as argument here.
		copy_grappa_coefficients_to_kernel_2d<<< gridDim, blockDim >>>( AHrhs.get_data_ptr(),
				gkernel.get_data_ptr(),
				source_coils,
				target_coils,
				dkernel_size,
				acceleration_factor,
				set);

		//write_cuNDArray_to_disk(&gkernel,"kernel.cplx");

		err = cudaGetLastError();
		if( err != cudaSuccess ){
			std::cerr << "htgrappa_calculate_grappa_unmixing: Failed to copy calculated coefficients to kernel: " <<
					cudaGetErrorString(err) << std::endl;
			return -1;
		}

	}

	//TODO: This should be source coils
	cuNDArray<T> tmp_mixing = cuNDArray<T>(ref_data->get_dimensions());

	int kernel_elements = gkernel.get_number_of_elements()/target_coils;
	int total_elements = tmp_mixing.get_number_of_elements()/source_coils;
	dkernel_size.y *= acceleration_factor;
	cuNDFFT<T> ft;
	std::vector<unsigned int> ft_dims(2,0);ft_dims[1] = 1;
	clear(out_mixing_coeff);
	unsigned int current_uncombined_index = 0;

	//TODO: Loop over target coils.
	for (unsigned int c = 0; c < target_coils; c++) {
		clear(&tmp_mixing);

		dim3 blockDim(512,1,1);
		dim3 gridDim((unsigned int) ceil((1.0f*kernel_elements)/blockDim.x), 1, 1 );

		//TODO: Take source and target into consideration
		copy_grappa_kernel_to_kspace_2d<<< gridDim, blockDim >>>((gkernel.get_data_ptr()+(c*kernel_elements)),
				tmp_mixing.get_data_ptr(),
				dims,
				dkernel_size,
				source_coils);

		cudaError_t err = cudaGetLastError();
		if( err != cudaSuccess ){
			std::cerr << "htgrappa_calculate_grappa_unmixing: Unable to pad GRAPPA kernel: " <<
					cudaGetErrorString(err) << std::endl;
			return -1;
		}

		ft.ifft(&tmp_mixing, &ft_dims);

		float scale_factor = total_elements;

		gridDim = dim3((unsigned int) ceil(1.0f*total_elements/blockDim.x), 1, 1 );
		scale_and_add_unmixing_coeffs<<< gridDim, blockDim >>>(tmp_mixing.get_data_ptr(),
				(b1->get_data_ptr()+ c*total_elements),
				out_mixing_coeff->get_data_ptr(),
				total_elements,
				source_coils,
				scale_factor);
		err = cudaGetLastError();
		if( err != cudaSuccess ){
			std::cerr << "htgrappa_calculate_grappa_unmixing: scale and add mixing coeffs: " <<
					cudaGetErrorString(err) << std::endl;
			return -1;
		}

		if (uncombined_channels) {
			std::list<unsigned int>::iterator it = std::find((*uncombined_channels).begin(),(*uncombined_channels).end(),c);
			if (it != (*uncombined_channels).end()) {
				current_uncombined_index++;
				scale_and_copy_unmixing_coeffs<<< gridDim, blockDim >>>(tmp_mixing.get_data_ptr(),
						(out_mixing_coeff->get_data_ptr()+current_uncombined_index*total_elements*source_coils),
						total_elements,
						source_coils,
						scale_factor);
			}
		}

	}

	//std::cout << "**********cublasDestroy()**************" << std::endl;
	//cublasDestroy_v2(handle);

	return 0;
}



//Template instanciation
template EXPORTGPUPMRI int htgrappa_calculate_grappa_unmixing(cuNDArray<complext<float> >* ref_data,
		cuNDArray<complext<float> >* b1,
		unsigned int acceleration_factor,
		std::vector<unsigned int> *kernel_size,
		cuNDArray<complext<float> >* out_mixing_coeff,
		std::vector< std::pair<unsigned int, unsigned int> >* sampled_region,
		std::list< unsigned int >* uncombined_channels);
